package gitcodemonitor

import std.sync.*
import std.time.*

public func gcmPluginLeaseHeartbeatOnce(leasePath: String, lease: GcmPluginLease, nowMs: Int64): GcmPluginLeaseIoResult {
    writeGcmPluginLease(leasePath, lease.withHeartbeat(nowMs))
}

public class GcmPluginLeaseHeartbeatRuntime {
    private let leasePath: String
    private let baseLease: GcmPluginLease
    private let intervalMs: Int64
    private let stopRequested = AtomicBool(false)
    private let lock = Mutex()
    private var worker: Option<Future<Unit>> = None

    public init(leasePath: String, lease: GcmPluginLease, intervalMs!: Int64 = 5000) {
        this.leasePath = leasePath.trimAscii()
        this.baseLease = lease
        this.intervalMs = if (intervalMs <= 0) { 5000 } else { intervalMs }
    }

    public func start(): Unit {
        if (this.leasePath.isEmpty()) {
            return
        }
        synchronized(this.lock) {
            if (this.worker.isSome()) {
                return
            }
            this.stopRequested.store(false)
            this.worker = spawn {
                this.runLoop()
            }
        }
    }

    public func stop(): Unit {
        this.stopRequested.store(true)
        let existing = synchronized(this.lock) {
            let current = this.worker
            this.worker = None<Future<Unit>>
            current
        }
        existing?.cancel()
        try { existing?.get() } catch (_: Exception) { () }
    }

    private func runLoop(): Unit {
        while (!this.stopRequested.load() && !Thread.currentThread.hasPendingCancellation) {
            let _ = gcmPluginLeaseHeartbeatOnce(
                this.leasePath,
                this.baseLease,
                DateTime.now().toUnixTimeStamp().toMilliseconds()
            )
            sleep(Duration.millisecond * this.intervalMs)
        }
    }
}
