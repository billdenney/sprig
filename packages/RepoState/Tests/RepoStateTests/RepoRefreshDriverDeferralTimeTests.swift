import Foundation
import GitCore
import PlatformKit
@testable import RepoState
import Testing

/// Tests for the ``RepoRefreshDriver/firstDeferralAt`` diagnostic — a
/// forward-compat enabler for ADR 0066 (stale `index.lock` recovery).
/// The agent's main loop will check `firstDeferralAt` on every tick
/// and surface a Notification Center alert when elapsed > 60s.
@Suite("RepoRefreshDriver — firstDeferralAt diagnostic (ADR 0066 enabler)")
struct RepoRefreshDriverDeferralTimeTests {
    private func event(path: String) -> WatchEvent {
        WatchEvent(path: URL(fileURLWithPath: path), kind: .modified)
    }

    /// Recording refresh closure: counts invocations and returns a
    /// canned outcome (overridable per-test). Same shape as the
    /// recorder used in `RepoRefreshDriverTests`.
    private actor Recorder {
        private(set) var nextOutcome: RefreshOutcome = .applied(entryCount: 0)

        func setNext(_ outcome: RefreshOutcome) {
            nextOutcome = outcome
        }

        func record() -> RefreshOutcome {
            nextOutcome
        }
    }

    private func makeRecorder() -> (Recorder, @Sendable () async -> RefreshOutcome) {
        let rec = Recorder()
        let closure: @Sendable () async -> RefreshOutcome = {
            await rec.record()
        }
        return (rec, closure)
    }

    @Test("firstDeferralAt is nil before any refresh has run")
    func startsNil() async {
        let (_, refresh) = makeRecorder()
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        #expect(await driver.firstDeferralAt == nil)
    }

    @Test("firstDeferralAt stays nil after a successful refresh")
    func nilOnSuccess() async {
        let (_, refresh) = makeRecorder()
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        _ = await driver.processEvents([event(path: "/x")])
        #expect(await driver.firstDeferralAt == nil)
    }

    @Test("firstDeferralAt is set on the first deferral")
    func setOnDefer() async {
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        let beforeFirst = Date()
        _ = await driver.processEvents([event(path: "/x")])
        let afterFirst = Date()
        if let stamped = await driver.firstDeferralAt {
            #expect(stamped >= beforeFirst)
            #expect(stamped <= afterFirst)
        } else {
            Issue.record("expected firstDeferralAt to be set after a deferred outcome")
        }
    }

    @Test("firstDeferralAt preserves the first timestamp across consecutive deferrals")
    func preservesFirstTimestamp() async {
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)

        _ = await driver.processEvents([event(path: "/x")])
        let firstStamp = await driver.firstDeferralAt

        // Sleep so a new Date() would be measurably greater.
        try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms

        // Second consecutive defer — timestamp must NOT advance.
        _ = await driver.processEvents([])
        let secondStamp = await driver.firstDeferralAt
        #expect(firstStamp == secondStamp)
    }

    @Test("firstDeferralAt clears when a refresh succeeds")
    func clearedOnApplied() async {
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        _ = await driver.processEvents([event(path: "/x")])
        #expect(await driver.firstDeferralAt != nil)

        await rec.setNext(.applied(entryCount: 0))
        _ = await driver.processEvents([])
        #expect(await driver.firstDeferralAt == nil)
    }

    @Test("firstDeferralAt clears when a refresh fails")
    func clearedOnFailed() async {
        struct Boom: Error {}
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)
        _ = await driver.processEvents([event(path: "/x")])
        #expect(await driver.firstDeferralAt != nil)

        await rec.setNext(.failed(Boom()))
        _ = await driver.processEvents([])
        #expect(await driver.firstDeferralAt == nil)
    }

    @Test("firstDeferralAt resets on a fresh deferral streak after success")
    func resetsAfterStreak() async {
        let (rec, refresh) = makeRecorder()
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        let driver = RepoRefreshDriver(gitDir: nil, refresh: refresh)

        // Streak 1.
        _ = await driver.processEvents([event(path: "/x")])
        let firstStreakStamp = await driver.firstDeferralAt

        // End streak with a success.
        await rec.setNext(.applied(entryCount: 0))
        _ = await driver.processEvents([])
        #expect(await driver.firstDeferralAt == nil)

        // Sleep so a new defer's stamp is measurably later.
        try? await Task.sleep(nanoseconds: 5_000_000)

        // Streak 2 — fresh timestamp, must be later than the first.
        await rec.setNext(.deferred(reason: .gitOperationInFlight))
        _ = await driver.processEvents([event(path: "/y")])
        let secondStreakStamp = await driver.firstDeferralAt
        #expect(secondStreakStamp != nil)
        if let firstStreakStamp, let secondStreakStamp {
            #expect(secondStreakStamp > firstStreakStamp)
        }
    }
}
