// AutoSyncSchedulerTests.swift
//
// Scheduler mechanics with an injected sleep — no wall-clock waits,
// no git. The SyncOps job content is covered by GitCore's
// SyncOpsTests; here we only prove the sequencing contract:
// fire-on-start, periodic firing, policy gating, overlap skip,
// stop(), and fireNow().

@testable import AgentKit
import Foundation
import PlatformKit
import Testing

/// Counts job invocations; lets tests await "fired at least N times".
private actor JobCounter {
    private(set) var count = 0
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        waiters.removeAll { waiter in
            if count >= waiter.threshold {
                waiter.continuation.resume()
                return true
            }
            return false
        }
    }

    func waitUntil(_ threshold: Int) async {
        if count >= threshold { return }
        await withCheckedContinuation { continuation in
            waiters.append((threshold, continuation))
        }
    }
}

/// Policy whose decision can be flipped mid-test.
private final class TogglePolicy: SyncPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var paused: Bool

    init(paused: Bool) {
        self.paused = paused
    }

    func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }

    func decision() -> SyncPolicyDecision {
        lock.withLock { paused ? .pause(reason: "test pause") : .allow }
    }
}

@Suite("AutoSyncScheduler — sequencing contract")
struct AutoSyncSchedulerTests {
    /// Sleep stub that yields (so cancellation is observed) without
    /// real waiting; ticks run as fast as the actor allows.
    private static let instantSleep: @Sendable (Duration) async throws -> Void = { _ in
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
    }

    @Test("fireOnStart fires immediately and the loop keeps ticking")
    func firesOnStartAndPeriodically() async {
        let counter = JobCounter()
        let scheduler = AutoSyncScheduler(
            configuration: AutoSyncConfiguration(
                interval: .seconds(3600), // irrelevant; sleep is stubbed
                jitterFraction: 0,
                fireOnStart: true
            ),
            sleep: Self.instantSleep,
            job: { await counter.record() }
        )
        await scheduler.start()
        await counter.waitUntil(3) // start-fire + ≥2 ticks
        await scheduler.stop()

        let diags = await scheduler.diagnostics()
        #expect(diags.firesCompleted >= 3)
        #expect(diags.ticksSkippedByPolicy == 0)
    }

    @Test("fireOnStart=false waits for the first tick")
    func noStartFire() async {
        let counter = JobCounter()
        let sleepEntered = JobCounter()
        let sleepRelease = JobCounter()
        let scheduler = AutoSyncScheduler(
            configuration: AutoSyncConfiguration(
                interval: .seconds(3600),
                jitterFraction: 0,
                fireOnStart: false
            ),
            sleep: { _ in
                await sleepEntered.record()
                await sleepRelease.waitUntil(1) // parks the first sleep
                try Task.checkCancellation()
            },
            job: { await counter.record() }
        )
        await scheduler.start()
        // The loop reached its first sleep WITHOUT firing the job —
        // exactly what fireOnStart=false promises.
        await sleepEntered.waitUntil(1)
        #expect(await counter.count == 0)

        await sleepRelease.record() // release the sleep → first tick
        await counter.waitUntil(1)
        await scheduler.stop()
        #expect(await counter.count >= 1)
    }

    @Test("policy pause skips ticks and records the reason; resume fires again")
    func policyPauseSkipsAndResumes() async {
        let counter = JobCounter()
        let policy = TogglePolicy(paused: true)
        let scheduler = AutoSyncScheduler(
            configuration: AutoSyncConfiguration(
                interval: .seconds(3600),
                jitterFraction: 0,
                fireOnStart: true
            ),
            policy: policy,
            sleep: Self.instantSleep,
            job: { await counter.record() }
        )
        await scheduler.start()

        // Let several gated ticks pass while paused.
        while await scheduler.diagnostics().ticksSkippedByPolicy < 3 {
            await Task.yield()
        }
        let pausedCount = await counter.count
        #expect(pausedCount == 0)

        policy.setPaused(false)
        await counter.waitUntil(1)
        await scheduler.stop()

        let diags = await scheduler.diagnostics()
        #expect(diags.firesCompleted >= 1)
        #expect(diags.ticksSkippedByPolicy >= 3)
        #expect(diags.lastPauseReason == "test pause")
    }

    @Test("stop() halts the loop; no fires arrive afterwards")
    func stopHalts() async {
        let counter = JobCounter()
        let scheduler = AutoSyncScheduler(
            configuration: AutoSyncConfiguration(
                interval: .seconds(3600),
                jitterFraction: 0,
                fireOnStart: true
            ),
            sleep: Self.instantSleep,
            job: { await counter.record() }
        )
        await scheduler.start()
        await counter.waitUntil(1)
        await scheduler.stop()

        let after = await counter.count
        // Generous yield window; the count must not move post-stop.
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(await counter.count == after)
    }

    @Test("fireNow() runs the job even while the policy pauses the loop")
    func fireNowBypassesPolicy() async {
        let counter = JobCounter()
        let policy = TogglePolicy(paused: true)
        let scheduler = AutoSyncScheduler(
            configuration: AutoSyncConfiguration(
                interval: .seconds(3600),
                jitterFraction: 0,
                fireOnStart: false
            ),
            policy: policy,
            sleep: Self.instantSleep,
            job: { await counter.record() }
        )
        await scheduler.start()
        let fired = await scheduler.fireNow()
        #expect(fired)
        #expect(await counter.count == 1)
        await scheduler.stop()
    }

    @Test("overlapping fire attempts are skipped, not queued")
    func overlapSkipped() async {
        let release = JobCounter()
        let entered = JobCounter()
        let scheduler = AutoSyncScheduler(
            configuration: AutoSyncConfiguration(
                interval: .seconds(3600),
                jitterFraction: 0,
                fireOnStart: false
            ),
            sleep: Self.instantSleep,
            job: {
                await entered.record()
                await release.waitUntil(1) // hold the job open
            }
        )
        // First fire occupies the job slot…
        let first = Task { await scheduler.fireNow() }
        await entered.waitUntil(1)
        // …second fire while held must be refused.
        let second = await scheduler.fireNow()
        #expect(second == false)
        let diags = await scheduler.diagnostics()
        #expect(diags.ticksSkippedOverlapping == 1)

        await release.record() // let the held job finish
        #expect(await first.value == true)
        await scheduler.stop()
    }
}
