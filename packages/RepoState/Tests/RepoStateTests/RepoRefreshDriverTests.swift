import Foundation
import GitCore
import PlatformKit
@testable import RepoState
import Testing

@Suite("RepoRefreshDriver — refresh trigger from watcher events")
struct RepoRefreshDriverTests {
    private func event(
        path: String,
        kind: WatchEventKind = .modified,
        date: Date = Date()
    ) -> WatchEvent {
        WatchEvent(path: URL(fileURLWithPath: path), kind: kind, timestamp: date)
    }

    /// Recording refresh closure: counts invocations and returns a
    /// canned outcome (overridable per-test).
    private actor Recorder {
        private(set) var calls: Int = 0
        private(set) var nextOutcome: RefreshOutcome = .applied(entryCount: 0)

        func setNext(_ outcome: RefreshOutcome) {
            nextOutcome = outcome
        }

        func record() -> RefreshOutcome {
            calls += 1
            return nextOutcome
        }
    }

    private func makeRecorder() -> (Recorder, @Sendable () async -> RefreshOutcome) {
        let rec = Recorder()
        let closure: @Sendable () async -> RefreshOutcome = {
            await rec.record()
        }
        return (rec, closure)
    }

    // MARK: empty-batch behavior

    @Test("processEvents with empty batch + no pending deferral does not refresh")
    func emptyBatchNoRefresh() async {
        let (rec, refresh) = makeRecorder()
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        let outcome = await driver.processEvents([])
        #expect(outcome == nil)
        #expect(await rec.calls == 0)
    }

    // MARK: filter rules

    @Test("a worktree-side event triggers a refresh")
    func worktreeEventTriggers() async {
        let (rec, refresh) = makeRecorder()
        let gitDir = URL(fileURLWithPath: "/repo/.git")
        let driver = RepoRefreshDriver(gitDir: gitDir, refresh: refresh)

        let outcome = await driver.processEvents([
            event(path: "/repo/src/main.swift")
        ])
        #expect(outcome != nil)
        #expect(await rec.calls == 1)
    }

    @Test("a `.git/index.lock` event alone does NOT trigger a refresh (transient mid-mutation)")
    func indexLockAloneNoRefresh() async {
        let (rec, refresh) = makeRecorder()
        let gitDir = URL(fileURLWithPath: "/repo/.git")
        let driver = RepoRefreshDriver(gitDir: gitDir, refresh: refresh)

        let outcome = await driver.processEvents([
            event(path: "/repo/.git/index.lock")
        ])
        #expect(outcome == nil)
        #expect(await rec.calls == 0)
    }

    @Test("a real `.git/`-internal change (e.g. index, HEAD) triggers a refresh")
    func realGitInternalEventTriggers() async {
        let (rec, refresh) = makeRecorder()
        let gitDir = URL(fileURLWithPath: "/repo/.git")
        let driver = RepoRefreshDriver(gitDir: gitDir, refresh: refresh)

        // `index` (no .lock) — git's atomic-rename target.
        _ = await driver.processEvents([event(path: "/repo/.git/index")])
        // `HEAD` rewrite — what `git checkout` does.
        _ = await driver.processEvents([event(path: "/repo/.git/HEAD")])
        // `refs/heads/main` rewrite — `git commit` updates this.
        _ = await driver.processEvents([event(path: "/repo/.git/refs/heads/main")])

        #expect(await rec.calls == 3)
    }

    @Test("a mix of worktree event + lock file: worktree wins; one refresh fires")
    func mixedBatchRefreshesOnce() async {
        let (rec, refresh) = makeRecorder()
        let gitDir = URL(fileURLWithPath: "/repo/.git")
        let driver = RepoRefreshDriver(gitDir: gitDir, refresh: refresh)

        let outcome = await driver.processEvents([
            event(path: "/repo/.git/index.lock"),
            event(path: "/repo/src/main.swift")
        ])
        #expect(outcome != nil)
        #expect(await rec.calls == 1) // not 2
    }

    @Test("an overflow event triggers a refresh even if every other event is noise")
    func overflowAlwaysTriggers() async {
        let (rec, refresh) = makeRecorder()
        let gitDir = URL(fileURLWithPath: "/repo/.git")
        let driver = RepoRefreshDriver(gitDir: gitDir, refresh: refresh)

        let outcome = await driver.processEvents([
            event(path: "/repo/.git/index.lock"),
            event(path: "/anywhere", kind: .overflow)
        ])
        #expect(outcome != nil)
        #expect(await rec.calls == 1)
    }

    @Test("when no gitDir is configured, every event triggers a refresh (conservative default)")
    func noGitDirConservative() async {
        let (rec, refresh) = makeRecorder()
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)

        // Even a path that *would* be a lock if gitDir were known.
        let outcome = await driver.processEvents([
            event(path: "/repo/.git/index.lock")
        ])
        #expect(outcome != nil)
        #expect(await rec.calls == 1)
    }

    @Test("pack-temp paths are filtered out as transient")
    func packTempFiltered() async {
        let (rec, refresh) = makeRecorder()
        let gitDir = URL(fileURLWithPath: "/repo/.git")
        let driver = RepoRefreshDriver(gitDir: gitDir, refresh: refresh)

        _ = await driver.processEvents([
            event(path: "/repo/.git/objects/pack/tmp_pack_abc")
        ])
        _ = await driver.processEvents([
            event(path: "/repo/.git/objects/pack/.tmp-XYZ-pack")
        ])
        #expect(await rec.calls == 0)
    }

    // MARK: deferred-retry semantics

    @Test("after a deferred refresh, the next processEvents retries even with empty batch")
    func deferredRetriesNextTick() async {
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        let gitDir = URL(fileURLWithPath: "/repo/.git")
        let driver = RepoRefreshDriver(gitDir: gitDir, refresh: refresh)

        // Tick 1: a real event triggers, but the refresh defers.
        let r1 = await driver.processEvents([event(path: "/repo/src/x.swift")])
        if case .deferred = r1 {} else {
            Issue.record("expected first outcome to be deferred, got \(String(describing: r1))")
        }
        #expect(await rec.calls == 1)

        // The lock has cleared by tick 2; reset the recorder's outcome.
        await rec.setNext(.applied(entryCount: 0))

        // Tick 2: empty batch — but we should retry because the prior
        // attempt was deferred.
        let r2 = await driver.processEvents([])
        if case .applied = r2 {} else {
            Issue.record("expected second outcome to be applied, got \(String(describing: r2))")
        }
        #expect(await rec.calls == 2)
    }

    @Test("after a deferred refresh, the retry's outcome clears the pending flag")
    func deferredFlagClearsAfterRetry() async {
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)

        _ = await driver.processEvents([event(path: "/x")])
        await rec.setNext(.applied(entryCount: 0))
        _ = await driver.processEvents([])
        #expect(await rec.calls == 2)

        // Tick 3: now the pending-deferred flag should be clear, so
        // an empty batch should NOT retry.
        let r3 = await driver.processEvents([])
        #expect(r3 == nil)
        #expect(await rec.calls == 2) // no new call
    }

    @Test("a failed refresh clears the pending-deferred flag (no retry-loop on failures)")
    func failureClearsPendingDeferred() async {
        struct Boom: Error {}
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.failed(Boom()))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)

        _ = await driver.processEvents([event(path: "/x")])
        // After a failure, the next empty batch should not retry —
        // we're not in deferred state.
        let r2 = await driver.processEvents([])
        #expect(r2 == nil)
        #expect(await rec.calls == 1)
    }

    // MARK: forceRefresh

    @Test("forceRefresh ignores filters and pending state")
    func forceRefreshAlwaysFires() async {
        let (rec, refresh) = makeRecorder()
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        _ = await driver.forceRefresh()
        _ = await driver.forceRefresh()
        #expect(await rec.calls == 2)
    }

    // MARK: diagnostics

    @Test("refreshAttempts and lastOutcome track invocations across ticks")
    func diagnosticsTrackInvocations() async {
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.applied(entryCount: 5))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        #expect(await driver.refreshAttempts == 0)
        #expect(await driver.lastOutcome == nil)

        _ = await driver.processEvents([event(path: "/x")])
        #expect(await driver.refreshAttempts == 1)
        if case let .applied(count) = await driver.lastOutcome {
            #expect(count == 5)
        } else {
            Issue.record("expected applied outcome")
        }

        _ = await driver.processEvents([event(path: "/y")])
        #expect(await driver.refreshAttempts == 2)
    }

    // MARK: convenience init that wraps RepoStatusRefresher

    @Test("the convenience init wraps a RepoStatusRefresher and routes through it")
    func wrapsRepoStatusRefresher() async {
        // We don't actually run git here — just construct the driver
        // via the convenience init and verify forceRefresh delegates.
        // The refresher's run-against-real-git path is exercised by
        // RepoStatusRefresherTests; we only need to prove the wiring.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-driver-wrap-\(UUID().uuidString)")
            .standardized
        let store = RepoStateStore(repoRoot: root)
        // RepoStatusRefresher with an unreachable repoRoot will get
        // a non-zero exit (nonRepo); we expect `.failed`.
        let refresher = RepoStatusRefresher(store: store)
        let driver = RepoRefreshDriver(refresher: refresher, gitDir: nil)
        let outcome = await driver.forceRefresh()
        if case .failed = outcome {
            // expected — there's no repo at that path
        } else {
            Issue.record("expected .failed (no repo), got \(outcome)")
        }
        #expect(await driver.refreshAttempts == 1)
    }
}
