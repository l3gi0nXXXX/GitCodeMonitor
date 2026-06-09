package gitcodemonitor

import std.collection.ArrayList
import std.fs.{File, Path, exists, remove}
import std.time.*
import std.unittest.testmacro.*

private class ServicePluginOnlyScanSender <: HttpSender {
    public let requests = ArrayList<HttpRequestSpec>()
    public init() {}

    public func send(request: HttpRequestSpec): HttpResponseSpec {
        requests.add(request)
        if (request.url.contains("/orgs/cangjie/repos")) {
            return HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true}]}")
        }
        if (request.url.contains("/repos/cangjie/compiler/issues?")) {
            return HttpResponseSpec(200, body: "{\"data\":[" +
                "{\"number\":11,\"title\":\"bug-11\",\"body\":\"details 11\",\"user\":{\"login\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/11\"}," +
                "{\"number\":12,\"title\":\"bug-12\",\"body\":\"details 12\",\"user\":{\"login\":\"bob\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/12\"}" +
            "]}")
        }
        if (request.url.contains("/issues/comments")) {
            return HttpResponseSpec(200, body: "[]")
        }
        if (request.url.contains("/pulls?")) {
            return HttpResponseSpec(200, body: "[]")
        }
        HttpResponseSpec(200, body: "{}")
    }
}

@Test
public class GitCodeMonitorPluginJobsTest {
    private func readFixture(name: String): String {
        let paths = [
            "test/fixtures/service_plugin/job_protocol/${name}",
            "../test/fixtures/service_plugin/job_protocol/${name}",
            "fixtures/service_plugin/job_protocol/${name}"
        ]
        for (path in paths) {
            if (exists(Path(path))) {
                return String.fromUtf8(File.readFrom(Path(path))).trimAscii()
            }
        }
        ""
    }

    private func tempStatePath(label: String): String {
        "/tmp/gcm-async-${label}-${DateTime.now().toUnixTimeStamp().toNanoseconds()}.json"
    }

    private func asyncScanFrame(jobId: String, offlineFixture!: Bool = true): ServiceFrame {
        ServiceFrame(
            "request",
            "scan-${jobId}",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.monitor.scan_once",
            correlationId: "corr-${jobId}",
            payload: "{" +
                "\"mode\":\"async\"," +
                "\"jobId\":\"${jobId}\"," +
                "\"idempotencyKey\":\"idem-${jobId}\"," +
                "\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"tg\",\"peerId\":\"peer-123\",\"threadId\":\"\",\"replyToMessageId\":\"24\",\"replyInThread\":false}," +
                "\"limits\":{\"maxRepos\":1,\"maxItems\":1,\"maxDurationMillis\":30000,\"perRequestTimeoutMillis\":1000,\"progressIntervalMillis\":1}," +
                "\"options\":{\"offlineFixture\":${offlineFixture},\"dryRun\":true}" +
            "}"
        )
    }

    private func asyncScanFrameWithLimits(jobId: String, limitsJson: String, offlineFixture!: Bool = false): ServiceFrame {
        ServiceFrame(
            "request",
            "scan-${jobId}",
            GCM_SERVICE_PLUGIN_ID,
            method: "invokeCapability",
            capabilityId: "gitcode.monitor.scan_once",
            correlationId: "corr-${jobId}",
            payload: "{" +
                "\"mode\":\"async\"," +
                "\"jobId\":\"${jobId}\"," +
                "\"idempotencyKey\":\"idem-${jobId}\"," +
                "\"deliveryTarget\":{\"channel\":\"telegram\",\"accountId\":\"tg\",\"peerId\":\"peer-123\",\"threadId\":\"\",\"replyToMessageId\":\"24\",\"replyInThread\":false}," +
                "\"limits\":${limitsJson}," +
                "\"options\":{\"offlineFixture\":${offlineFixture},\"dryRun\":true}" +
            "}"
        )
    }

    private func enqueueRepoWithIssueBatch(fakeSender: FakeHttpSender, repoName: String, issueCount: Int64): Unit {
        var body = "{\"data\":["
        for (i in 0..issueCount) {
            if (i > 0) { body += "," }
            body += "{\"number\":${i + 1},\"title\":\"issue-${repoName}-${i}\",\"body\":\"details\",\"user\":{\"login\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/${repoName}/issues/${i + 1}\"}"
        }
        body += "]}"
        fakeSender.enqueue(HttpResponseSpec(200, body: body))
        for (_ in 0..issueCount) {
            fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        }
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
    }

    @TestCase
    public func jobProtocolFixturesDecodeAndValidatePayloads(): Unit {
        let start = decodeServiceFrame(readFixture("scan_start_async_request.jsonl"))
        @Expect(start.ok, true)
        @Expect(start.frame.capabilityId, "gitcode.monitor.scan_once")
        let parsedStart = parseGcmAsyncScanPayload(start.frame.payload)
        @Expect(parsedStart.ok, true)
        @Expect(parsedStart.payload.mode, "async")
        @Expect(parsedStart.payload.jobId, "gcm-scan-20260530-095017-0001")
        @Expect(parsedStart.payload.limits.maxRepos, 0)
        @Expect(parsedStart.payload.limits.maxItems, 0)
        @Expect(parsedStart.payload.limits.maxDurationMillis, 0)

        let accepted = decodeServiceFrame(readFixture("scan_accepted_response.jsonl"))
        @Expect(accepted.ok, true)
        let acceptedPayload = parseGcmJobAcceptedPayload(accepted.frame.payload, "gcm-scan-20260530-095017-0001")
        @Expect(acceptedPayload.ok, true)
        @Expect(acceptedPayload.jobId, "gcm-scan-20260530-095017-0001")

        let completed = decodeServiceFrame(readFixture("scan_completed_event.jsonl"))
        @Expect(completed.ok, true)
        let completedPayload = parseGcmJobEventPayload(completed.frame.capabilityId, completed.frame.payload)
        @Expect(completedPayload.ok, true)
        @Expect(completedPayload.status, "completed")
        @Expect(completedPayload.summary.contains("accepted=1"), true)

        let failed = decodeServiceFrame(readFixture("scan_failed_event.jsonl"))
        @Expect(failed.ok, true)
        let failedPayload = parseGcmJobEventPayload(failed.frame.capabilityId, failed.frame.payload)
        @Expect(failedPayload.ok, true)
        @Expect(failedPayload.status, "failed")
        @Expect(failedPayload.summary.contains("gitcode_timeout"), true)
    }

    @TestCase
    public func asyncScanPayloadRejectsMalformedTypesAndUnsafeIds(): Unit {
        @Expect(parseGcmAsyncScanPayload("[]").status, "job_payload_invalid")
        @Expect(parseGcmAsyncScanPayload("{\"mode\":\"async\",\"jobId\":\"\",\"deliveryTarget\":{\"peerId\":\"peer\"}}").status, "job_payload_invalid")
        @Expect(parseGcmAsyncScanPayload("{\"mode\":\"async\",\"jobId\":\"gcm-scan\",\"deliveryTarget\":{\"peerId\":123}}").status, "job_payload_invalid")
        var longJobId = ""
        for (_ in 0..129) { longJobId += "x" }
        @Expect(parseGcmAsyncScanPayload("{\"mode\":\"async\",\"jobId\":\"${longJobId}\",\"deliveryTarget\":{\"peerId\":\"peer\"}}").status, "job_payload_invalid")
    }

    @TestCase
    public func asyncScanPayloadLimitsDefaultAndLegacyDurationCompatibility(): Unit {
        let missingLimits = parseGcmAsyncScanPayload("{" +
            "\"mode\":\"async\",\"jobId\":\"job-missing-limits\",\"deliveryTarget\":{\"peerId\":\"peer\"}" +
        "}")
        @Expect(missingLimits.ok, true)
        @Expect(missingLimits.payload.limits.maxRepos, 0)
        @Expect(missingLimits.payload.limits.maxItems, 0)
        @Expect(missingLimits.payload.limits.maxDurationMillis, 0)

        let emptyLimits = parseGcmAsyncScanPayload("{" +
            "\"mode\":\"async\",\"jobId\":\"job-empty-limits\",\"deliveryTarget\":{\"peerId\":\"peer\"},\"limits\":{}" +
        "}")
        @Expect(emptyLimits.ok, true)
        @Expect(emptyLimits.payload.limits.maxRepos, 0)
        @Expect(emptyLimits.payload.limits.maxItems, 0)
        @Expect(emptyLimits.payload.limits.maxDurationMillis, 0)

        let legacyDuration = parseGcmAsyncScanPayload("{" +
            "\"mode\":\"async\",\"jobId\":\"job-legacy-duration\",\"deliveryTarget\":{\"peerId\":\"peer\"}," +
            "\"limits\":{\"maxRepos\":0,\"maxItems\":0,\"maxDurationMillis\":1}" +
        "}")
        @Expect(legacyDuration.ok, true)
        @Expect(legacyDuration.payload.limits.maxDurationMillis, 0)

        let badDurationType = parseGcmAsyncScanPayload("{" +
            "\"mode\":\"async\",\"jobId\":\"job-bad-duration\",\"deliveryTarget\":{\"peerId\":\"peer\"}," +
            "\"limits\":{\"maxDurationMillis\":\"bad\"}" +
        "}")
        @Expect(badDurationType.ok, false)
        @Expect(badDurationType.diagnostic, "limits fields must be integers")

        let negativeDuration = parseGcmAsyncScanPayload("{" +
            "\"mode\":\"async\",\"jobId\":\"job-negative-duration\",\"deliveryTarget\":{\"peerId\":\"peer\"}," +
            "\"limits\":{\"maxDurationMillis\":-1}" +
        "}")
        @Expect(negativeDuration.ok, false)
        @Expect(negativeDuration.diagnostic, "limits must be non-negative")
    }

    @TestCase
    public func jobStoreReusesIdempotencyKeyRejectsConcurrencyAndCancels(): Unit {
        let store = GcmScanJobStore(maxConcurrent: 1)
        let payload = parseGcmAsyncScanPayload(asyncScanFrame("job-store-1").payload).payload
        let first = store.createOrGet(payload)
        @Expect(first.ok, true)
        @Expect(first.job.jobId, "job-store-1")
        @Expect(first.alreadyRunning, false)

        let duplicate = store.createOrGet(payload)
        @Expect(duplicate.ok, true)
        @Expect(duplicate.alreadyRunning, true)
        @Expect(duplicate.job.jobId, "job-store-1")

        let secondPayload = parseGcmAsyncScanPayload(asyncScanFrame("job-store-2").payload).payload
        let rejected = store.createOrGet(secondPayload)
        @Expect(rejected.ok, false)
        @Expect(rejected.status, "job_rejected")

        let cancelled = store.requestCancel("job-store-1")
        @Expect(cancelled.ok, true)
        @Expect(cancelled.job.cancelRequested, true)
    }

    @TestCase
    public func asyncRuntimeReturnsAcceptedThenEmitsProgressAndCompletedFrames(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-completed")
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let store = GcmScanJobStore(maxConcurrent: 1)
        let frame = asyncScanFrame("job-runtime-completed")

        let handled = handleGcmPluginInputLineWithJobs(encodeServiceFrame(frame).trimAscii(), config, runtime, state, store)
        @Expect(handled.ok, true)
        @Expect(handled.asyncJobId, "job-runtime-completed")
        writer.writeFrame(handled.frame)
        startGcmScanJobWorker(handled.asyncJobId, config, runtime, state, store, writer)
        waitForGcmJobTerminal(store, "job-runtime-completed", timeoutMs: 3000)

        @Expect(sink.lines.size >= 3, true)
        let accepted = decodeServiceFrame(sink.lines[0])
        @Expect(accepted.ok, true)
        @Expect(parseGcmJobAcceptedPayload(accepted.frame.payload, "job-runtime-completed").ok, true)
        @Expect(decodeServiceFrame(sink.lines[1]).frame.capabilityId, "gitcode.monitor.scan_progress")
        @Expect(decodeServiceFrame(sink.lines[sink.lines.size - 1]).frame.capabilityId, "gitcode.monitor.scan_completed")
        @Expect(decodeServiceFrame(sink.lines[sink.lines.size - 1]).frame.payload.contains("\"summary\""), true)

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func asyncRuntimeEmitsAcceptedEventForEachNewItem(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-accepted-event")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"data\":[{\"number\":11,\"title\":\"bug\",\"body\":\"details\",\"user\":{\"login\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/11\"}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        state.markBaseline("gitcode:cangjie/compiler", 0)
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let store = GcmScanJobStore(maxConcurrent: 1)
        let frame = asyncScanFrame("job-runtime-accepted-event", offlineFixture: false)

        let handled = handleGcmPluginInputLineWithJobs(encodeServiceFrame(frame).trimAscii(), config, runtime, state, store)
        writer.writeFrame(handled.frame)
        startGcmScanJobWorker(handled.asyncJobId, config, runtime, state, store, writer)
        waitForGcmJobTerminal(store, "job-runtime-accepted-event", timeoutMs: 3000)

        var acceptedEvents: Int64 = 0
        var completedPayload = ""
        for (line in sink.lines) {
            let decoded = decodeServiceFrame(line)
            if (decoded.ok && decoded.frame.capabilityId == "gitcode.event.accepted") {
                acceptedEvents++
                @Expect(decoded.frame.payload.contains("\"jobId\": \"job-runtime-accepted-event\""), true)
                @Expect(decoded.frame.payload.contains("\"eventId\": \"gitcode:cangjie/compiler:issue:11\""), true)
                @Expect(decoded.frame.payload.contains("https://gitcode.com/cangjie/compiler/issues/11"), true)
            }
            if (decoded.ok && decoded.frame.capabilityId == "gitcode.monitor.scan_completed") {
                completedPayload = decoded.frame.payload
            }
        }
        @Expect(acceptedEvents, 1)
        @Expect(completedPayload.contains("\"newEvents\": 1"), true)
        @Expect(completedPayload.contains("\"samples\""), true)

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func asyncRuntimeFirstScanSeedsBaselineAndSuppressesAcceptedEvents(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-baseline-seed")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"data\":[{\"number\":11,\"title\":\"history\",\"body\":\"details\",\"user\":{\"login\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/11\"}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let store = GcmScanJobStore(maxConcurrent: 1)
        let frame = asyncScanFrame("job-runtime-baseline-seed", offlineFixture: false)

        let handled = handleGcmPluginInputLineWithJobs(encodeServiceFrame(frame).trimAscii(), config, runtime, state, store)
        writer.writeFrame(handled.frame)
        startGcmScanJobWorker(handled.asyncJobId, config, runtime, state, store, writer)
        waitForGcmJobTerminal(store, "job-runtime-baseline-seed", timeoutMs: 3000)

        var acceptedEvents: Int64 = 0
        var completedPayload = ""
        for (line in sink.lines) {
            let decoded = decodeServiceFrame(line)
            if (decoded.ok && decoded.frame.capabilityId == "gitcode.event.accepted") {
                acceptedEvents++
            }
            if (decoded.ok && decoded.frame.capabilityId == "gitcode.monitor.scan_completed") {
                completedPayload = decoded.frame.payload
            }
        }
        @Expect(acceptedEvents, 0)
        @Expect(completedPayload.contains("\"baseline\""), true)
        @Expect(completedPayload.contains("\"seededEvents\": 1"), true)
        @Expect(completedPayload.contains("\"createdScopes\": 1"), true)
        @Expect(completedPayload.contains("\"newEvents\": 0"), true)
        @Expect(state.hasBaseline("gitcode:cangjie/compiler"), true)
        @Expect(state.hasSeen("gitcode:cangjie/compiler:issue:11"), true)

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func asyncRuntimeEmitsFailedFrameWhenFakeTransportFails(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-failed")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.nextResponse = HttpResponseSpec(599, body: "transport_error: timeout")
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let store = GcmScanJobStore(maxConcurrent: 1)
        let frame = asyncScanFrame("job-runtime-failed", offlineFixture: false)

        let accepted = handleGcmPluginInputLineWithJobs(encodeServiceFrame(frame).trimAscii(), config, runtime, state, store)
        writer.writeFrame(accepted.frame)
        startGcmScanJobWorker(accepted.asyncJobId, config, runtime, state, store, writer)
        waitForGcmJobTerminal(store, "job-runtime-failed", timeoutMs: 3000)

        let failed = decodeServiceFrame(sink.lines[sink.lines.size - 1])
        @Expect(failed.frame.capabilityId, "gitcode.monitor.scan_failed")
        @Expect(parseGcmJobEventPayload(failed.frame.capabilityId, failed.frame.payload).status, "failed")

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func boundedRuntimeHonorsMaxReposBeforeFetchingSecondRepository(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-bounds")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true},{\"path\":\"runtime\",\"public\":true}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"data\":[{\"number\":11,\"title\":\"bug\",\"body\":\"details\",\"user\":{\"login\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/11\"}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let job = GcmScanJob(payload: parseGcmAsyncScanPayload(asyncScanFrame("job-runtime-bounded").payload).payload)

        let result = scanOnceRuntimeBoundedForJob(config, runtime, state, job)

        @Expect(result.accepted + result.ignored <= 1, true)
        @Expect(result.stopReason, "max_repos_reached")
        var fetchedRuntimeRepo = false
        for (request in fakeSender.requests) {
            if (request.url.contains("/repos/cangjie/runtime/")) {
                fetchedRuntimeRepo = true
            }
        }
        @Expect(fetchedRuntimeRepo, false)

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func boundedRuntimeHonorsMaxItemsAndReportsStopReason(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-max-items")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true}]}"))
        enqueueRepoWithIssueBatch(fakeSender, "compiler", 6)
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let job = GcmScanJob(payload: parseGcmAsyncScanPayload(asyncScanFrameWithLimits("job-runtime-max-items", "{\"maxRepos\":0,\"maxItems\":3,\"maxDurationMillis\":0}").payload).payload)

        let result = scanOnceRuntimeBoundedForJob(config, runtime, state, job)

        @Expect(result.checkedItems, 3)
        @Expect(result.stopReason, "max_items_reached")

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func asyncRuntimeDefaultLimitsDoNotStopAtFiveReposOrThirtyItems(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-unbounded-default")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[" +
            "{\"path\":\"repo-0\",\"public\":true}," +
            "{\"path\":\"repo-1\",\"public\":true}," +
            "{\"path\":\"repo-2\",\"public\":true}," +
            "{\"path\":\"repo-3\",\"public\":true}," +
            "{\"path\":\"repo-4\",\"public\":true}," +
            "{\"path\":\"repo-5\",\"public\":true}," +
            "{\"path\":\"repo-6\",\"public\":true}," +
            "{\"path\":\"repo-7\",\"public\":true}," +
            "{\"path\":\"repo-8\",\"public\":true}," +
            "{\"path\":\"repo-9\",\"public\":true}," +
            "{\"path\":\"repo-10\",\"public\":true}," +
            "{\"path\":\"repo-11\",\"public\":true}" +
        "]}"))
        for (i in 0..12) {
            enqueueRepoWithIssueBatch(fakeSender, "repo-${i}", 7)
        }
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let job = GcmScanJob(payload: parseGcmAsyncScanPayload(asyncScanFrameWithLimits("job-runtime-unbounded-default", "{\"maxRepos\":0,\"maxItems\":0,\"maxDurationMillis\":0}").payload).payload)

        let result = scanOnceRuntimeBoundedForJob(config, runtime, state, job)

        @Expect(result.scannedRepos >= 6, true)
        @Expect(result.checkedItems > 30, true)
        @Expect(result.stopReason, "completed")

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func legacyDurationLimitDoesNotStopAsyncRuntime(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-legacy-duration")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true}]}"))
        enqueueRepoWithIssueBatch(fakeSender, "compiler", 6)
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        let job = GcmScanJob(payload: parseGcmAsyncScanPayload(asyncScanFrameWithLimits("job-runtime-legacy-duration", "{\"maxRepos\":0,\"maxItems\":0,\"maxDurationMillis\":1}").payload).payload)

        let result = scanOnceRuntimeBoundedForJob(config, runtime, state, job)

        @Expect(job.limits.maxDurationMillis, 0)
        @Expect(result.checkedItems, 6)
        @Expect(result.stopReason, "completed")

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func boundedRuntimeReportCountsDuplicateEventsAndScanScope(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-report-duplicates")
        config.orgs = ["cangjie"]
        let fakeSender = FakeHttpSender()
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"repos\":[{\"path\":\"compiler\",\"public\":true}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "{\"data\":[{\"number\":11,\"title\":\"bug\",\"body\":\"details\",\"user\":{\"login\":\"alice\"},\"html_url\":\"https://gitcode.com/cangjie/compiler/issues/11\"}]}"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        fakeSender.enqueue(HttpResponseSpec(200, body: "[]"))
        let sender: HttpSender = fakeSender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(sender))
        let state = runtime.store.load()
        state.markBaseline("gitcode:cangjie/compiler", 0)
        state.markSeen("gitcode:cangjie/compiler:issue:11")
        let job = GcmScanJob(payload: parseGcmAsyncScanPayload(asyncScanFrame("job-runtime-report-duplicates").payload).payload)

        let result = scanOnceRuntimeBoundedForJob(config, runtime, state, job)

        @Expect(result.scannedRepos, 1)
        @Expect(result.checkedItems, 1)
        @Expect(result.newEvents, 0)
        @Expect(result.duplicateEvents, 1)
        @Expect(result.samplesDuplicate.size, 1)
        @Expect(result.samplesDuplicate[0].reason, "seen")

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func completedPayloadIncludesStructuredReportAndLegacyFields(): Unit {
        let payload = parseGcmAsyncScanPayload(asyncScanFrame("job-report-payload").payload).payload
        let store = GcmScanJobStore(maxConcurrent: 1)
        let created = store.createOrGet(payload)
        let result = ScanResult(0, 0, 0, 0, 0, scannedRepos: 1, checkedItems: 6, duplicateEvents: 6, baselineScopesCreated: 1, baselineSeededEvents: 3, writeMode: "dry_run")
        for (i in 0..6) {
            result.addDuplicateSample(GitCodeEvent(
                "dup-${i}",
                "cangjie",
                "compiler",
                "issue",
                "${i}",
                "alice",
                "",
                "https://gitcode.com/cangjie/compiler/issues/${i}?access_token=secret-token",
                "Authorization: Bearer secret-token /Users/alice/private"
            ), "seen")
        }

        let completed = store.markCompleted(created.job.jobId, result, true)
        let payloadText = gcmScanJobEventPayload(completed.job)
        let snapshotText = gcmJobSnapshotPayload(completed.job)

        @Expect(payloadText.contains("\"accepted\":0"), true)
        @Expect(payloadText.contains("\"ignored\":0"), true)
        @Expect(payloadText.contains("\"writes\":0"), true)
        @Expect(payloadText.contains("\"report\""), true)
        @Expect(payloadText.contains("\"stopReason\":\"completed\""), true)
        @Expect(payloadText.contains("\"scannedRepos\":1"), true)
        @Expect(payloadText.contains("\"checkedItems\":6"), true)
        @Expect(payloadText.contains("\"duplicateEvents\":6"), true)
        @Expect(payloadText.contains("\"baseline\""), true)
        @Expect(payloadText.contains("\"createdScopes\":1"), true)
        @Expect(payloadText.contains("\"seededEvents\":3"), true)
        @Expect(payloadText.contains("\"baselineSeededEvents\":3"), true)
        @Expect(payloadText.contains("\"status\":\"created\""), true)
        @Expect(payloadText.contains("\"writeMode\":\"dry_run\""), true)
        @Expect(payloadText.contains("\"duplicate\""), true)
        @Expect(payloadText.contains("\"sampleRemaining\""), true)
        @Expect(payloadText.contains("\"duplicate\":1"), true)
        @Expect(payloadText.split("\"reason\":\"seen\"").size, 6)
        @Expect(payloadText.contains("secret-token"), false)
        @Expect(payloadText.contains("/Users/alice"), false)
        @Expect(snapshotText.contains("\"report\""), true)
    }

    @TestCase
    public func failedPayloadAndSnapshotIncludeRedactedDiagnostic(): Unit {
        let payload = parseGcmAsyncScanPayload(asyncScanFrame("job-failed-diagnostic").payload).payload
        let store = GcmScanJobStore(maxConcurrent: 1)
        let created = store.createOrGet(payload)
        let diagnostic = "{\"stage\":\"scan_runtime\",\"errorKind\":\"timeout\",\"errorHash\":\"payload-67-67\",\"message\":\"Authorization: Bearer secret-token /Users/alice/.metis\"}"

        let failed = store.markFailed(created.job.jobId, "scan_runtime", "timeout", diagnostic: diagnostic)
        let payloadText = gcmScanJobEventPayload(failed.job)
        let snapshotText = gcmJobSnapshotPayload(failed.job)

        @Expect(payloadText.contains("\"errorKind\":\"timeout\""), true)
        @Expect(payloadText.contains("\"diagnostic\""), true)
        @Expect(payloadText.contains("\"stage\""), true)
        @Expect(payloadText.contains("\"errorHash\""), true)
        @Expect(snapshotText.contains("\"diagnostic\""), true)
        @Expect(payloadText.contains("secret-token"), false)
        @Expect(snapshotText.contains("secret-token"), false)
        @Expect(payloadText.contains("Authorization"), false)
        @Expect(snapshotText.contains("/Users/alice"), false)
    }

    @TestCase
    public func scanRuntimeErrorClassificationUsesReadableKinds(): Unit {
        @Expect(gcmClassifyScanRuntimeError("Invalid utf8 byte sequence."), "invalid_utf8")
        @Expect(gcmClassifyScanRuntimeError("request timeout after 1000 ms"), "timeout")
        @Expect(gcmClassifyScanRuntimeError("JSON parse error at byte 1"), "json_parse_error")
        @Expect(gcmClassifyScanRuntimeError("something unexpected"), "runtime_exception")
    }

    @TestCase
    public func scanRuntimeDiagnosticRedactsSensitiveContent(): Unit {
        let diagnostic = gcmScanRuntimeDiagnostic("scan_runtime", "Authorization: Bearer secret-token /Users/alice/.metis/state.json")

        @Expect(diagnostic.contains("\"stage\""), true)
        @Expect(diagnostic.contains("\"errorKind\""), true)
        @Expect(diagnostic.contains("\"errorHash\""), true)
        @Expect(diagnostic.contains("secret-token"), false)
        @Expect(diagnostic.contains("Authorization"), false)
        @Expect(diagnostic.contains("/Users/alice"), false)
    }

    @TestCase
    public func boundedRuntimeAcceptsEventsWithoutLegacyMcpCall(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-event-isolation")
        config.orgs = ["cangjie"]
        config.mcpEndpoint = "http://127.0.0.1:8787/mcp"
        let sender = ServicePluginOnlyScanSender()
        let httpSender: HttpSender = sender
        let runtime = RuntimeContainer(config, sender: Some<HttpSender>(httpSender))
        let state = runtime.store.load()
        state.markBaseline("gitcode:cangjie/compiler", 0)
        let job = GcmScanJob(payload: parseGcmAsyncScanPayload(asyncScanFrameWithLimits("job-runtime-event-isolation", "{\"maxRepos\":0,\"maxItems\":0,\"maxDurationMillis\":0}").payload).payload)

        let result = scanOnceRuntimeBoundedForJob(config, runtime, state, job)

        @Expect(result.stopReason, "completed")
        @Expect(result.checkedItems, 2)
        @Expect(result.failedEvents, 0)
        @Expect(result.newEvents, 2)
        @Expect(result.mcpCalls, 0)
        @Expect(result.samplesNew.size, 2)
        @Expect(state.hasSeen("gitcode:cangjie/compiler:issue:11"), true)
        @Expect(state.hasSeen("gitcode:cangjie/compiler:issue:12"), true)
        var mcpCallRequestFound = false
        for (request in sender.requests) {
            if (request.body.contains("\"method\":\"tools/call\"")) {
                mcpCallRequestFound = true
            }
        }
        @Expect(mcpCallRequestFound, false)

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func jobStatusAndCancelCapabilitiesUseJobSnapshotsWithoutScanning(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-cancel")
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let sink = GcmMemoryLineSink()
        let writer = GcmPluginStdioWriter(sink)
        let store = GcmScanJobStore(maxConcurrent: 1)
        let frame = asyncScanFrame("job-runtime-cancel")

        let accepted = handleGcmPluginInputLineWithJobs(encodeServiceFrame(frame).trimAscii(), config, runtime, state, store)
        writer.writeFrame(accepted.frame)
        let cancelFrame = ServiceFrame("request", "cancel-job-runtime-cancel", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.monitor.cancel_job", correlationId: "corr-cancel", payload: "{\"jobId\":\"job-runtime-cancel\"}")
        let cancel = handleGcmPluginInputLineWithJobs(encodeServiceFrame(cancelFrame).trimAscii(), config, runtime, state, store)
        @Expect(cancel.frame.payload.contains("\"status\":\"cancel_requested\""), true)
        writer.writeFrame(cancel.frame)
        startGcmScanJobWorker(accepted.asyncJobId, config, runtime, state, store, writer)
        waitForGcmJobTerminal(store, "job-runtime-cancel", timeoutMs: 3000)

        let statusFrame = ServiceFrame("request", "status-job-runtime-cancel", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.monitor.job_status", correlationId: "corr-status", payload: "{\"jobId\":\"job-runtime-cancel\"}")
        let status = handleGcmPluginInputLineWithJobs(encodeServiceFrame(statusFrame).trimAscii(), config, runtime, state, store)
        @Expect(status.frame.payload.contains("\"status\":\"cancelled\""), true)
        @Expect(sink.lines[sink.lines.size - 1].contains("scan_cancelled"), true)

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }

    @TestCase
    public func jobStatusAndCancelRejectUnsafeJobIds(): Unit {
        let config = defaultConfig()
        config.fullScanIntervalMinutes = 10
        config.statePath = tempStatePath("runtime-invalid-job-id")
        let runtime = RuntimeContainer(config)
        let state = runtime.store.load()
        let store = GcmScanJobStore(maxConcurrent: 1)
        let statusFrame = ServiceFrame("request", "status-invalid", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.monitor.job_status", correlationId: "corr-status-invalid", payload: "{\"jobId\":\"../state\"}")
        let cancelFrame = ServiceFrame("request", "cancel-invalid", GCM_SERVICE_PLUGIN_ID, method: "invokeCapability", capabilityId: "gitcode.monitor.cancel_job", correlationId: "corr-cancel-invalid", payload: "{\"jobId\":\"job with space\"}")

        let status = handleGcmPluginInputLineWithJobs(encodeServiceFrame(statusFrame).trimAscii(), config, runtime, state, store)
        let cancel = handleGcmPluginInputLineWithJobs(encodeServiceFrame(cancelFrame).trimAscii(), config, runtime, state, store)

        @Expect(status.ok, false)
        @Expect(status.frame.payload.contains("\"status\":\"job_payload_invalid\""), true)
        @Expect(cancel.ok, false)
        @Expect(cancel.frame.payload.contains("\"status\":\"job_payload_invalid\""), true)

        if (exists(Path(config.statePath))) { remove(Path(config.statePath)) }
    }
}
